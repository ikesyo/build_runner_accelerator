import 'package:json_annotation/json_annotation.dart';

part 'model_006.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model006 {
  const Model006({required this.id, required this.value});

  final int id;
  final String value;

  factory Model006.fromJson(Map<String, dynamic> json) =>
      _$Model006FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model006ToJson(this);
}
