import 'package:json_annotation/json_annotation.dart';

part 'model_062.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model062 {
  const Model062({required this.id, required this.value});

  final int id;
  final String value;

  factory Model062.fromJson(Map<String, dynamic> json) =>
      _$Model062FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model062ToJson(this);
}
