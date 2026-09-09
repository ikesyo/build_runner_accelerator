import 'package:json_annotation/json_annotation.dart';

part 'model_035.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model035 {
  const Model035({required this.id, required this.value});

  final int id;
  final String value;

  factory Model035.fromJson(Map<String, dynamic> json) =>
      _$Model035FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model035ToJson(this);
}
