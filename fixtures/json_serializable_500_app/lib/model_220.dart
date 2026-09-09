import 'package:json_annotation/json_annotation.dart';

part 'model_220.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model220 {
  const Model220({required this.id, required this.value});

  final int id;
  final String value;

  factory Model220.fromJson(Map<String, dynamic> json) =>
      _$Model220FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model220ToJson(this);
}
