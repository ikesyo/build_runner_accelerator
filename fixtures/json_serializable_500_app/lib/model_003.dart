import 'package:json_annotation/json_annotation.dart';

part 'model_003.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model003 {
  const Model003({required this.id, required this.value});

  final int id;
  final String value;

  factory Model003.fromJson(Map<String, dynamic> json) =>
      _$Model003FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model003ToJson(this);
}
