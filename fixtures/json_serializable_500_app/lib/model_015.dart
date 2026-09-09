import 'package:json_annotation/json_annotation.dart';

part 'model_015.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model015 {
  const Model015({required this.id, required this.value});

  final int id;
  final String value;

  factory Model015.fromJson(Map<String, dynamic> json) =>
      _$Model015FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model015ToJson(this);
}
