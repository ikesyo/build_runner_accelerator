import 'package:json_annotation/json_annotation.dart';

part 'model_305.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model305 {
  const Model305({required this.id, required this.value});

  final int id;
  final String value;

  factory Model305.fromJson(Map<String, dynamic> json) =>
      _$Model305FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model305ToJson(this);
}
