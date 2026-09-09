import 'package:json_annotation/json_annotation.dart';

part 'model_435.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model435 {
  const Model435({required this.id, required this.value});

  final int id;
  final String value;

  factory Model435.fromJson(Map<String, dynamic> json) =>
      _$Model435FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model435ToJson(this);
}
