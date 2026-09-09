import 'package:json_annotation/json_annotation.dart';

part 'model_171.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model171 {
  const Model171({required this.id, required this.value});

  final int id;
  final String value;

  factory Model171.fromJson(Map<String, dynamic> json) =>
      _$Model171FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model171ToJson(this);
}
