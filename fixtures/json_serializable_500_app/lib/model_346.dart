import 'package:json_annotation/json_annotation.dart';

part 'model_346.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model346 {
  const Model346({required this.id, required this.value});

  final int id;
  final String value;

  factory Model346.fromJson(Map<String, dynamic> json) =>
      _$Model346FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model346ToJson(this);
}
